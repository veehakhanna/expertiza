class AssignmentsController < ApplicationController
  include AssignmentHelper
  include AuthorizationHelper
  autocomplete :user, :name
  before_action :authorize

  # either current_user is an super/admin or instructor for the assignment
  # or a TA for the course exists or owner of the Course
  def action_allowed?
    if %w[edit update list_submissions].include? params[:action]
      current_user_has_admin_privileges? || current_user_teaching_staff_of_assignment?(params[:id])
    else
      current_user_has_ta_privileges?
    end
  end

  def new
    @assignment_form = AssignmentForm.new
    @assignment_form.assignment.instructor ||= current_user
    @num_submissions_round = 0
    @num_reviews_round = 0
  end

  def create
    @assignment_form = AssignmentForm.new(assignment_form_params)
    if params[:button]
      if @assignment_form.save
        @assignment_form.create_assignment_node

        # update ids in the form
        if update_assignment_form
          # send out success notifications and navigate to edit page
          aid = Assignment.find_by(name: @assignment_form.assignment.name).id
          ExpertizaLogger.info "Assignment created: #{@assignment_form.as_json}"
          redirect_to edit_assignment_path aid
          undo_link("Assignment \"#{@assignment_form.assignment.name}\" has been created successfully. ")
        else
          flash.now[:error] = "Failed to update assignment IDs"
          render 'new'
        end

      else
        flash.now[:error] = "Failed to create assignment"
        render 'new'
      end
    else
      render 'new'
      undo_link("Assignment \"#{@assignment_form.assignment.name}\" has been created successfully. ")
    end
  end

  def edit
    ExpertizaLogger.error LoggerMessage.new(controller_name, session[:user].name, "Timezone not specified", request) if current_user.timezonepref.nil?
    flash.now[:error] = "You have not specified your preferred timezone yet. Please do this before you set up the deadlines." if current_user.timezonepref.nil?
    edit_params_setting
    assignment_staggered_deadline?
    @due_date_all.each do |dd|
      check_due_date_nameurl(dd)
      adjust_timezone_when_due_date_present(dd)
      break if validate_due_date
    end
    check_assignment_questionnaires_usage
    @due_date_all = update_due_date_deadline_name(@due_date_all)
    @due_date_all = update_due_date_description_url(@due_date_all)
    # only when instructor does not assign rubrics and in assignment edit page will show this error message.
    handle_rubrics_not_assigned_case
    missing_submission_directory
    # assigned badges will hold all the badges that have been assigned to an assignment
    # added it to display the assigned badges while creating a badge in the assignments page
    @assigned_badges = @assignment_form.assignment.badges
    @badges = Badge.all
    @use_bookmark = @assignment.use_bookmark
  end

  def update
    unless params.key?(:assignment_form)
      assignment_submission_handler
      return
    end
    retrieve_assignment_form
    timezone_handler
    update_feedback_attributes
    redirect_to edit_assignment_path @assignment_form.assignment.id
  end

  def show
    @assignment = Assignment.find(params[:id])
  end

  def path
    begin
      file_path = @assignment.path
    rescue StandardError
      file_path = nil
    end
    file_path
  end

  def copy
    @user = current_user
    session[:copy_flag] = true
    # check new assignment submission directory and old assignment submission directory
    old_assign = Assignment.find(params[:id])
    new_assign_id = AssignmentForm.copy(params[:id], @user)
    if new_assign_id
      new_assign = Assignment.find(new_assign_id)
      if old_assign.directory_path == new_assign.directory_path
        flash[:note] = "Warning: The submission directory for the copy of this assignment will be the same as the submission directory "\
          "for the existing assignment. This will allow student submissions to one assignment to overwrite submissions to the other assignment. "\
          "If you do not want this to happen, change the submission directory in the new copy of the assignment."
      end
      redirect_to edit_assignment_path new_assign_id
    else
      flash[:error] = 'The assignment was not able to be copied. Please check the original assignment for missing information.'
      redirect_to list_tree_display_index_path
    end
  end

  def delete
    begin
      assignment_form = AssignmentForm.create_form_object(params[:id])
      user = session[:user]
      # Issue 1017 - allow instructor to delete assignment created by TA.
      # FixA : TA can only delete assignment created by itself.
      # FixB : Instrucor will be able to delete any assignment belonging to his/her courses.
      if user.role.name == 'Instructor' or (user.role.name == 'Teaching Assistant' and user.id == assignment_form.assignment.instructor_id)
        assignment_form.delete(params[:force])
        ExpertizaLogger.info LoggerMessage.new(controller_name, session[:user].name, "Assignment #{assignment_form.assignment.id} was deleted.", request)
        flash[:success] = 'The assignment was successfully deleted.'
      else
        ExpertizaLogger.info LoggerMessage.new(controller_name, session[:user].name, 'You are not authorized to delete this assignment.', request)
        flash[:error] = 'You are not authorized to delete this assignment.'
      end
    rescue StandardError => e
      flash[:error] = e.message
    end

    redirect_to list_tree_display_index_path
  end

  def delayed_mailer
    @suggestions = Suggestion.where(assignment_id: params[:id])
    @assignment = Assignment.find(params[:id])
  end

  def associate_assignment_with_course
    @assignment = Assignment.find(params[:id])
    @courses = Assignment.assign_courses_to_assignment(current_user)
  end

  def list_submissions
    @assignment = Assignment.find(params[:id])
    @teams = Team.where(parent_id: params[:id])
  end

  def remove_assignment_from_course
    assignment = Assignment.find(params[:id])
    Assignment.remove_assignment_from_course(assignment)
    redirect_to list_tree_display_index_path
  end

  def delete_delayed_mailer
    queue = Sidekiq::Queue.new("mailers")
    queue.each do |job|
      job.delete if job.jid == params[:delayed_job_id]
    end
    redirect_to delayed_mailer_assignments_index_path params[:id]
  end

  private

  # The questionnaire array and due date params are updated for the current user
  def update_assignment_form
    exist_assignment = Assignment.find_by(name: @assignment_form.assignment.name)
    assignment_form_params[:assignment][:id] = exist_assignment.id.to_s
    if assignment_form_params[:assignment][:directory_path].blank?
      assignment_form_params[:assignment][:directory_path] = "assignment_#{assignment_form_params[:assignment][:id]}"
    end

    ques_array = assignment_form_params[:assignment_questionnaire]
    ques_array = array_traverser(ques_array, 1)
    assignment_form_params[:assignment_questionnaire] = ques_array

    due_array = assignment_form_params[:due_date]
    due_array = array_traverser(due_array, 2)
    assignment_form_params[:due_date] = due_array

    @assignment_form.update(assignment_form_params, current_user)
  end

  # Iterates through an array and makes each id a string.
  def array_traverser(temp_array, option)
    exist_assignment = Assignment.find_by(name: @assignment_form.assignment.name)
    temp_array.each do |cur_ele|
      if option == 1
        cur_ele[:assignment_id] = exist_assignment.id.to_s
      else
        cur_ele[:parent_id] = exist_assignment.id.to_s
      end
    end
    temp_array
  end

  # check whether rubrics are set before save assignment
  def empty_rubrics_list
    rubrics_list = %w[ReviewQuestionnaire
                      MetareviewQuestionnaire AuthorFeedbackQuestionnaire
                      TeammateReviewQuestionnaire BookmarkRatingQuestionnaire]
    @assignment_questionnaires.each do |aq|
      next if aq.questionnaire_id.nil?

      rubrics_list.reject! do |rubric|
        rubric == Questionnaire.where(id: aq.questionnaire_id).first.type.to_s
      end
    end
    rubrics_list.delete('TeammateReviewQuestionnaire') if @assignment_form.assignment.max_team_size == 1
    rubrics_list.delete('MetareviewQuestionnaire') unless @metareview_allowed
    rubrics_list.delete('BookmarkRatingQuestionnaire') unless @assignment_form.assignment.use_bookmark
    rubrics_list
  end

  def needed_rubrics(empty_rubrics_list)
    needed_rub = '<b>['
    empty_rubrics_list.each do |item|
      needed_rub += item[0...-13] + ', '
    end
    needed_rub = needed_rub[0...-2]
    needed_rub += '] </b>'
  end

  def due_date_nameurl_not_empty?(dd)
    dd.deadline_name.present? || dd.description_url.present?
  end

  def meta_review_allowed?(dd)
    dd.deadline_type_id == DeadlineHelper::DEADLINE_TYPE_METAREVIEW
  end

  def drop_topic_allowed?(dd)
    dd.deadline_type_id == DeadlineHelper::DEADLINE_TYPE_DROP_TOPIC
  end

  def signup_allowed?(dd)
    dd.deadline_type_id == DeadlineHelper::DEADLINE_TYPE_SIGN_UP
  end

  def team_formation_allowed?(dd)
    dd.deadline_type_id == DeadlineHelper::DEADLINE_TYPE_TEAM_FORMATION
  end

  # Iterates through all the due dates and sets the deadline name to ''
  def update_due_date_deadline_name(due_date_all)
    due_date_all.each do |dd|
      dd.deadline_name ||= ''
    end
    due_date_all
  end

  # Iterates through all the due dates and sets the description url to ''
  def update_due_date_description_url(due_date_all)
    due_date_all.each do |dd|
      dd.description_url ||= ''
    end
    due_date_all
  end

  # When there is a staggered deadline the submission due date and the review due date deadline_type_id are set
  # If the assignment deadline is not staggered then set the variable to true
  def assignment_staggered_deadline?
    if @assignment_form.assignment.staggered_deadline #== true
      @review_rounds = @assignment_form.assignment.num_review_rounds
      @assignment_submission_due_dates = @due_date_all.select {|due_date| due_date.deadline_type_id == DeadlineHelper::DEADLINE_TYPE_SUBMISSION }
      @assignment_review_due_dates = @due_date_all.select {|due_date| due_date.deadline_type_id == DeadlineHelper::DEADLINE_TYPE_REVIEW }
    end
    # if it is not true then set it to true
    @assignment_form.assignment.staggered_deadline == true
  end

  def adjust_timezone_when_due_date_present(dd)
    dd.due_at = dd.due_at.to_s.in_time_zone(current_user.timezonepref) if dd.due_at.present?
  end

  def validate_due_date
    @due_date_nameurl_not_empty && @due_date_nameurl_not_empty_checkbox &&
      (@metareview_allowed || @drop_topic_allowed || @signup_allowed || @team_formation_allowed)
  end

  def check_assignment_questionnaires_usage
    @assignment_questionnaires.each do |aq|
      unless aq.used_in_round.nil?
        @reviewvarycheck = 1
        break
      end
    end
  end

  def handle_rubrics_not_assigned_case
    if !empty_rubrics_list.empty? && request.original_fullpath == "/assignments/#{@assignment_form.assignment.id}/edit"
      rubrics_needed = needed_rubrics(empty_rubrics_list)
      ExpertizaLogger.error LoggerMessage.new(controller_name, session[:user].name, "Rubrics missing for #{@assignment_form.assignment.name}.", request)
      if flash.now[:error] != "Failed to save the assignment: [\"Total weight of rubrics should add up to either 0 or 100%\"]"
        flash.now[:error] = "You did not specify all the necessary rubrics. You need " + rubrics_needed +
            " of assignment <b>#{@assignment_form.assignment.name}</b> before saving the assignment. You can assign rubrics" \
            " <a id='go_to_tabs2' style='color: blue;'>here</a>."
      end
    end
  end

  # When the submission directory is not set flash error and log
  # Otherwise when answer tagging is allowed then tagpromptdeployment is initialized with assignment id
  def missing_submission_directory
    if @assignment_form.assignment.directory_path.blank?
      flash.now[:error] = "You did not specify your submission directory."
      ExpertizaLogger.error LoggerMessage.new(controller_name, "", "Submission directory not specified", request)
    end
    @assignment_form.tag_prompt_deployments = TagPromptDeployment.where(assignment_id: params[:id]) if @assignment_form.assignment.is_answer_tagging_allowed
  end

  def retrieve_assignment_form
    @assignment_form = AssignmentForm.create_form_object(params[:id])
    @assignment_form.assignment.instructor ||= current_user
    params[:assignment_form][:assignment_questionnaire].reject! do |q|
      q[:questionnaire_id].empty?
    end

    # Deleting Due date info from table if meta-review is unchecked. - UNITY ID: ralwan and vsreeni
    @due_date_info = DueDate.find_each(parent_id: params[:id])

    DueDate.where(parent_id: params[:id], deadline_type_id: 5).destroy_all if params[:metareviewAllowed] == "false"
  end

  # If the current user has not set the time zone then flash a message
  # Then set the time zone equal to the parent timezone
  def timezone_handler
    if current_user.timezonepref.nil?
      parent_id = current_user.parent_id
      parent_timezone = User.find(parent_id).timezonepref
      flash[:error] = "We strongly suggest that instructors specify their preferred timezone to guarantee the correct display time. For now we assume you are in " + parent_timezone
      current_user.timezonepref = parent_timezone
    end
  end

  # When there have been submissions for reviews then the number of reviews expected can not be reduced
  # If there are no reviews yet then update the assignment if possible and log results
  def update_feedback_attributes
    if params[:set_pressed][:bool] == 'false'
      flash[:error] = "There has been some submissions for the rounds of reviews that you're trying to reduce. You can only increase the round of review."
    elsif params[:assignment_form][:assignment][:reviewer_is_team] != @assignment_form.assignment.reviewer_is_team.to_s && num_responses > 0
      flash[:error] = "You cannot change whether reviewers are teams if reviews have already been completed."
    else
      if @assignment_form.update_attributes(assignment_form_params, current_user)
        flash[:note] = 'The assignment was successfully saved....'
      else
        flash[:error] = "Failed to save the assignment: #{@assignment_form.errors.get(:message)}"
      end
    end
    ExpertizaLogger.info LoggerMessage.new("", session[:user].name, "The assignment was saved: #{@assignment_form.as_json}", request)
  end

  def assignment_form_params
    params.require(:assignment_form).permit!
  end

  # helper methods for edit
  def edit_params_setting
    @assignment = Assignment.find(params[:id])
    @num_submissions_round = @assignment.find_due_dates('submission').nil? ? 0 : @assignment.find_due_dates('submission').count
    @num_reviews_round = @assignment.find_due_dates('review').nil? ? 0 : @assignment.find_due_dates('review').count

    @topics = SignUpTopic.where(assignment_id: params[:id])
    @assignment_form = AssignmentForm.create_form_object(params[:id])
    @user = current_user

    @assignment_questionnaires = AssignmentQuestionnaire.where(assignment_id: params[:id])
    @due_date_all = AssignmentDueDate.where(parent_id: params[:id])
    @reviewvarycheck = false
    @due_date_nameurl_not_empty = false
    @due_date_nameurl_not_empty_checkbox = false
    @metareview_allowed = false
    @metareview_allowed_checkbox = false
    @signup_allowed = false
    @signup_allowed_checkbox = false
    @drop_topic_allowed = false
    @drop_topic_allowed_checkbox = false
    @team_formation_allowed = false
    @team_formation_allowed_checkbox = false
    @participants_count = @assignment_form.assignment.participants.size
    @teams_count = @assignment_form.assignment.teams.size
  end
end
